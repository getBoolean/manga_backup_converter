import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:mangabackupconverter/src/features/example_feature/domain/value/email.dart';
import 'package:mangabackupconverter/src/features/example_feature/domain/value/id.dart';
import 'package:mangabackupconverter/src/features/example_feature/domain/value/name.dart';
import 'package:modddels_annotation_fpdart/modddels_annotation_fpdart.dart';

part 'user_account.freezed.dart';
part 'user_account.modddel.dart';

@Modddel(
  validationSteps: [
    ValidationStep([
      contentValidation,
    ]),
    ValidationStep(
      [
        Validation('account', FailureType<UserAccountValidFailure>()),
      ],
      name: 'Value',
    ),
  ],
)
class UserAccount extends SimpleEntity<InvalidUserAccount, ValidUserAccount>
    with _$UserAccount {
  factory UserAccount({
    required Id id,
    required Name name,
    required Email email,
  }) {
    return _$UserAccount._create(id: id, name: name, email: email);
  }
  UserAccount._();

  @override
  Option<UserAccountValidFailure> validateAccount(
    _ValidateUserAccountAccount userAccount,
  ) {
    return none();
  }
}

@freezed
class UserAccountValidFailure extends EntityFailure
    with _$UserAccountValidFailure {
  const factory UserAccountValidFailure.invalid() = _Invalid;
}

final UserAccount user = UserAccount(
  id: Id('id'),
  name: Name(firstName: 'firstName', lastName: 'lastName'),
  email: Email('email'),
);
